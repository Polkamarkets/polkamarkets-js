class Question {

  static delimiter = '\u241f';

  static encodeText(qtype, txt, outcomes, category, lang) {
    var qtext = txt;
  
    var delim = this.delimiter;
  
    if (qtype == 'single-select' || qtype == 'multiple-select') {
        var outcome_str = JSON.stringify(outcomes).replace(/^\[/, '').replace(/\]$/, '');
  
        qtext = [qtext, outcome_str].join(delim);
    }
  
    if (typeof lang == 'undefined' || lang == '') {
        lang = 'en_US';
    }
  
    qtext = [qtext, category, lang].join(delim);
  
    return qtext;
  }
}

module.exports = Question;